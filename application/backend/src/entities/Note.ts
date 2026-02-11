import { Entity, PrimaryGeneratedColumn, Column, CreateDateColumn } from "typeorm";

@Entity({ name: "notes" })
export class Note {
    @PrimaryGeneratedColumn()
    id!: number;

    @Column({ unique: true })
    name!: string;

    @Column("text")
    content!: string;

    @CreateDateColumn()
    createdAt!: Date;
}